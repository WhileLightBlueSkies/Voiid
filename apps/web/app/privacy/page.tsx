import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { Hero } from '../../components/Hero';
import { Section, Grid, Split } from '../../components/Section';
import { FeatureCard } from '../../components/FeatureCard';
import { CTA } from '../../components/CTA';
import { Button, ButtonRow } from '../../components/Button';
import { E2EEBadge } from '../../components/E2EEBadge';
import { LockMotif } from '../../components/LockMotif';
import { Callout } from '../../components/Callout';
import { Glyph } from '../../components/Glyph';
import { CONTACT, CONTACT_INCOMPLETE, type ContactField } from '../../lib/contact';
import styles from './page.module.css';

export const metadata: Metadata = {
  title: 'Privacy architecture',
  description:
    'Exactly what Voiid can and cannot see. Messages, calls, location shares and ' +
    'moments are end-to-end encrypted; clips, creator profiles and games are not. ' +
    'Plus the metadata we hold and our posture under the DPDP Act, 2023.',
};

/* ---------------------------------------------------------------------------
 * SOURCES FOR EVERY CLAIM ON THIS PAGE. Checked before writing, not after.
 *
 * E2EE, server holds ciphertext and no key:
 *   messages            006_messages.sql (no plaintext column), 013_message_ciphertexts.sql
 *   groups              011_mls.sql — RFC 9420, server relays opaque MLS bytes, no group keys
 *   calls               014_calls.sql (media + SRTP keys on-device; the row is the LOG),
 *                       routes/calls.ts:206-210 (group calls: LiveKit SFU forwards frames
 *                       encrypted before they reach it)
 *   location            018_location_shares.sql (no lat, no lon, no ciphertext, no key)
 *   moments/stories     017_stories.sql (ciphertext + per-device key envelopes; the
 *                       server DOES learn which devices got key material — said so)
 *   backups             012_recovery.sql + routes/backup.ts (blob encrypted on-device)
 *
 * NOT E2EE, deliberately:
 *   clips               022_clips.sql header
 *   creator profiles    029_creator_profiles.sql header
 *   game state          024_games.sql header
 *
 * Metadata / collection:
 *   devices             002_devices.sql + 030_dpdp.sql §3 (os_version, app_version; NO ip)
 *   ip addresses        009_security_events.sql — abuse telemetry only
 *   contacts            008_contact_sync.sql — address book never uploaded
 *   reachability        020_reachability.sql — mutual contact, request, or @username + PIN
 *
 * DPDP posture — WHAT HAS AND HAS NOT SHIPPED. This is where a marketing page would
 * normally lie, so it is spelled out:
 *   LIVE, USER-REACHABLE ON BOTH PLATFORMS — safe to state in the present tense:
 *     Profile editing (routes/users.ts:105 + ProfileService.swift / ProfileService.kt);
 *     visibility controls for photo, about and last-seen, plus read-receipt and
 *     typing switches (019_privacy.sql + PrivacySettingsView.swift /
 *     PrivacySettingsScreen.kt); linked devices (LinkedDevicesView.swift /
 *     LinkedDevicesScreen.kt); safety numbers (SafetyNumberView.swift /
 *     SafetyNumberScreen.kt). DELETE /users/me revokes devices and invalidates the
 *     auth cache at once (auth.ts:51 re-checks deleted_at), and a soft-deleted
 *     account is refused at OTP verify rather than silently resurrected.
 *
 *   IN FLIGHT — the DPDP layer is being landed by parallel work as this page is
 *     written, so DO NOT re-assert a snapshot of it. As of writing: 030_dpdp.sql and
 *     031_consent_notice.sql give consent records, a notice registry, the retention
 *     policy table and devices.os_version/app_version; 032_erasure.sql plus
 *     workers/src/erasure.ts and retention.ts are wired into the workers loop
 *     (workers/src/index.ts:43-45); routes/consent.ts exists but is NOT yet mounted
 *     in index.ts; the iOS consent prompt and in-app legal documents exist and the
 *     Android twin does not. NOTHING here is reachable by a user on both platforms
 *     yet, which is why every `stands` field below is phrased as USER-FACING
 *     AVAILABILITY ("not yet available") rather than as internal build state. That
 *     phrasing stays true as the pieces land; a file-by-file status would not.
 *
 *   STILL ABSENT: an access-request export, an in-app delete-account control, and an
 *     age gate. Do not imply any of the three.
 *
 * [COUNSEL] — 11_admin_dpdp.md §6 and 030_dpdp.sql. Every retention duration is an
 * engineering placeholder (counsel_reviewed defaults to false). Nothing on this page
 * may read as a certification of compliance. Commitments, not certificates.
 *
 * AMBER BUDGET: spent on the single <E2EEBadge state="refereed"> in the Games card.
 * No accent Button, no accent CTA, no games hue anywhere else on this page.
 * ------------------------------------------------------------------------ */

/* =========================================================================
 * The envelope — this page's authored visual.
 *
 * It is here to teach the one thing people get wrong about end-to-end encryption:
 * the difference between the address on the outside and the letter on the inside.
 * The dashed line from the server deliberately touches the TOP HALF ONLY.
 *
 * The information is repeated as real text in the <dl> below, so nothing is
 * available only inside the picture.
 * ====================================================================== */

/** Ragged byte-block rows. Fixed literals — SSG output must be deterministic. */
const CIPHER_ROWS: number[][] = [
  [40, 24, 54, 30, 44, 26, 58],
  [30, 50, 22, 64, 36, 28, 48],
  [56, 26, 42, 34, 60, 22],
];

const ENVELOPE_LABEL =
  'Diagram: one message as our servers store it. The top of the envelope is an ' +
  'address panel our servers read — who it is from, which conversation it belongs ' +
  'to, and when it was sent. Below a dividing line, the message itself is drawn as ' +
  'unreadable blocks of ciphertext, marked "we hold no key". A dashed line from the ' +
  'server touches the address panel only, and never the contents.';

function CipherRow({ y, widths }: { y: number; widths: number[] }) {
  let x = 72;
  return (
    <>
      {widths.map((w, i) => {
        const rect = <rect key={i} x={x} y={y} width={w} height={18} rx={6} />;
        x += w + 8;
        return rect;
      })}
    </>
  );
}

function EnvelopeDiagram() {
  return (
    <figure className={styles.figure}>
      <svg
        className={styles.envelope}
        viewBox="0 0 520 442"
        width={520}
        height={442}
        role="img"
        aria-label={ENVELOPE_LABEL}
      >
        {/* ---- the server, and the one thing it is allowed to touch ---------- */}
        <g className={styles.server}>
          <rect x="186" y="6" width="148" height="36" rx="12" />
          <text x="260" y="30" textAnchor="middle" className={styles.serverText}>
            our server
          </text>
        </g>
        <path
          d="M260 44 V 70"
          className={styles.reach}
          strokeDasharray="4 6"
          strokeLinecap="round"
        />
        <path d="M253 64 L260 73 L267 64" className={styles.reachHead} fill="none" />

        {/* ---- the envelope --------------------------------------------------
         * Painted in four passes so the outline survives: body fill, then the
         * address panel's tint over it, then the seal, then the outline last. A
         * single stroked rect underneath would have its inner half covered by the
         * tint and read as a thinner border along the top. */}
        <rect x="40" y="74" width="440" height="356" rx="24" className={styles.paperFill} />

        {/* The address panel: rounded at the top, square where the seal is. */}
        <path
          d="M40 98 A24 24 0 0 1 64 74 H456 A24 24 0 0 1 480 98 V228 H40 Z"
          className={styles.panel}
        />
        <path d="M40 228 H480" className={styles.seal} />
        <rect x="40" y="74" width="440" height="356" rx="24" className={styles.paperEdge} />

        <text x="72" y="110" className={styles.eyebrowRead}>
          WE READ THIS TO DELIVER IT
        </text>

        <text x="72" y="152" className={styles.rowKey}>
          from
        </text>
        <text x="176" y="152" className={styles.rowValue}>
          your account
        </text>

        <text x="72" y="184" className={styles.rowKey}>
          to
        </text>
        <text x="176" y="184" className={styles.rowValue}>
          this conversation
        </text>

        <text x="72" y="216" className={styles.rowKey}>
          at
        </text>
        <text x="176" y="216" className={styles.rowValue}>
          5 Aug · 19:04
        </text>

        {/* ---- the contents -------------------------------------------------- */}
        <text x="72" y="266" className={styles.eyebrowSealed}>
          WE CANNOT READ THIS
        </text>

        <g className={styles.cipher}>
          <CipherRow y={286} widths={CIPHER_ROWS[0]} />
          <CipherRow y={312} widths={CIPHER_ROWS[1]} />
          <CipherRow y={338} widths={CIPHER_ROWS[2]} />
        </g>

        <g className={styles.verdict}>
          <rect x="125" y="372" width="230" height="42" rx="21" className={styles.verdictPill} />
          <rect x="169" y="386" width="18" height="13" rx="3.5" />
          <path d="M173.5 386 v-4 a4.5 4.5 0 0 1 9 0 v4" fill="none" />
          <text x="196" y="399" className={styles.verdictText}>
            we hold no key
          </text>
        </g>
      </svg>

      <figcaption className={styles.figcaption}>
        One message, drawn the way our database actually holds it. Everything above the
        seal is routing information — we need it to get the message to the right device.
        Everything below it is a blob that only your friend&rsquo;s device can open. There
        is no plaintext column in that table; not as a policy we could revise, as a schema.
      </figcaption>
    </figure>
  );
}

/* ---------------------------------------------------------------------------
 * The metadata inventory. Each entry is a surface, and the sentence after it is
 * the honest statement from that surface's own schema.
 * ------------------------------------------------------------------------ */

type MetaEntry = { term: string; sees: ReactNode; blind: ReactNode };

const METADATA: MetaEntry[] = [
  {
    term: 'Messages',
    sees: 'Who sent it, which conversation it belongs to, when it was sent, which devices it was addressed to, and when each of them collected it.',
    blind: 'A single word of what it said, or a single byte of any photo, voice note or file attached to it.',
  },
  {
    term: 'Calls',
    sees: 'Who called whom, in which conversation, whether it was voice or video, when it started, whether it was answered, when it ended and why.',
    blind: 'The audio, the video, and the keys — those are derived on the two devices. In a group call the media server forwards frames that were already encrypted before they reached it.',
  },
  {
    term: 'Location',
    sees: 'That a share exists, who it is with, and when it stops. Every share is time-boxed; there is no indefinite option.',
    blind: 'Where you are. There is no latitude or longitude column anywhere in our database. Live positions are relayed and never written down; a dropped pin is an ordinary encrypted message.',
  },
  {
    term: 'Moments',
    sees: 'Which devices you sent key material to. That is the audience, and we do not pretend to hide it.',
    blind: 'The photo or video, the caption, the real file type, the dimensions. The media is encrypted on your phone before it is uploaded.',
  },
  {
    term: 'Your account',
    sees: 'Your phone number — the account is the number — your @username, and whatever you chose to put in your profile.',
    blind: 'Your address book. Contact matching runs on your phone; we store only the links between Voiid accounts you matched, never the raw contacts.',
  },
  {
    term: 'Your devices',
    sees: 'The name the device reports, its platform, its OS and app version, and a push token for content-free wake-ups.',
    blind: 'Your IP address. There is deliberately no IP column on the device record, and that decision is written into the schema so nobody adds one later thinking it is harmless.',
  },
  {
    term: 'IP addresses',
    sees: 'Recorded only in security telemetry — a rate-limit breach, an abuse of the reachability rules, a failed login.',
    blind: 'Anything joining them to a message or a call. Security telemetry is a separate table with its own retention, and nothing in the messaging path reads it.',
  },
];

/* ---------------------------------------------------------------------------
 * The DPDP rights. `stands` is the load-bearing field: it is what stops a
 * commitment from being read as a certificate.
 * ------------------------------------------------------------------------ */

type Right = {
  title: string;
  section: string;
  commitment: string;
  stands: string;
  state: 'live' | 'partial' | 'building';
};

const RIGHTS: Right[] = [
  {
    title: 'Notice and consent',
    section: 'ss. 5–6',
    commitment:
      'An itemised notice before you agree to anything, and a consent record that names which version of that notice you saw, in which language, and for which purposes — not a bare timestamp.',
    stands:
      'Rolling out with the next builds. Until you have actually been shown the notice and asked, we are not going to describe you as having consented — which is why this says "not yet" rather than pointing at a checkbox nobody could read.',
    state: 'building',
  },
  {
    title: 'Access',
    section: 's. 11',
    commitment:
      'An export of everything above: your account row, your devices, your consent records, your clips.',
    stands:
      'Not available yet. When it is, it will not contain message content — there is none to give you. That is a property of the design, not an evasion, and it is the same answer a court would get.',
    state: 'building',
  },
  {
    title: 'Correction',
    section: 's. 12',
    commitment:
      'Anything you told us about yourself, you can change or remove.',
    stands:
      'Live on both platforms today. Name, photo, about and username are editable in the app, and you set who may see your photo, your about text and your last-seen — everyone, contacts only, or nobody. Read receipts and typing indicators are switches you own too.',
    state: 'live',
  },
  {
    title: 'Erasure',
    section: 'ss. 8(7), 12',
    commitment:
      'Deletion that removes the phone number, not a flag that hides the row. A grace period, then a real purge of devices, keys, shares and content.',
    stands:
      'Partly. Asking for deletion already revokes every device and stops your session on its very next request, rather than leaving a token alive for weeks, and a deleted account cannot sign back in with the same number. The scheduled purge that finally removes the phone number, and the control in the app that starts the whole thing, are the parts still landing.',
    state: 'partial',
  },
  {
    title: 'Withdrawing consent',
    section: 's. 6(4)',
    commitment:
      'Withdrawal has to be as easy as giving, so it is recorded on the same row as the grant — never by deleting the record, which would erase the evidence that the earlier period was lawful.',
    stands:
      'Ships with the consent screen: one control, in the same place, taking one tap. A product where consent is a tick and withdrawal is a support email has not met s. 6(4).',
    state: 'building',
  },
  {
    title: 'Grievances',
    section: 's. 13',
    commitment:
      'A named officer, contactable at an address in India, who answers questions about your data and complaints about content.',
    stands:
      'Not appointed. The block below is deliberately empty rather than filled with a plausible inbox — see it for why.',
    state: 'building',
  },
];

/*
 * User-facing availability, not internal build state — the DPDP layer is landing in
 * parallel with this page, and a chip that named a file would be wrong by Friday.
 */
const STATE_COPY: Record<Right['state'], string> = {
  live: 'Live today',
  partial: 'Partly available',
  building: 'Not yet available',
};

/* ---------------------------------------------------------------------------
 * Retention. Declared in the schema, and not yet enforced by a running job —
 * which is exactly what the last column says.
 * ------------------------------------------------------------------------ */

const RETENTION: { what: string; why: string; how: string }[] = [
  {
    what: 'Your login-code record — phone number, hashed code',
    why: 'Sending and checking the SMS code. It has no purpose once it has expired.',
    how: '24 hours after the code expires',
  },
  {
    what: 'Security telemetry — IP address, phone number, event type',
    why: 'Investigating abuse: rate-limit breaches, reachability abuse, failed logins. Nothing else reads it.',
    how: '90 days',
  },
  {
    what: 'Staff sign-in sessions — admin IP and browser',
    why: 'Letting us spot a stolen staff session. Never a Voiid user; the moderation plane is a separate login.',
    how: 'When the session expires',
  },
  {
    what: 'Call-quality samples',
    why: 'Reliability trends. Bucketed by the hour with no user id and no call id — these are not call records.',
    how: '90 days',
  },
  {
    what: 'Your account, devices and consent records',
    why: 'Identity, push routing, and the evidence that processing had a lawful basis.',
    how: 'As long as the account exists, then erasure',
  },
  {
    what: 'Clips and comments',
    why: 'Public content you chose to post.',
    how: 'Until you delete them',
  },
];

/* ---------------------------------------------------------------------------
 * Grievance block. Reads the same source as the footer, and renders the same
 * way: visibly unfilled, never plausible-looking.
 * ------------------------------------------------------------------------ */

function Pending({ field }: { field: ContactField }) {
  if (field.placeholder) return <span className={styles.pending}>{field.value}</span>;
  return field.href ? <a href={field.href}>{field.value}</a> : <span>{field.value}</span>;
}

export default function PrivacyPage() {
  return (
    <>
      <Hero
        hue="privacy"
        eyebrow="Privacy architecture"
        title={<>Everything we can&rsquo;t see &mdash; and the short list of what we can.</>}
        lede={
          <>
            Every privacy page says &ldquo;we take your privacy seriously.&rdquo; This one
            says which tables exist, what is in them, and which four features we chose not
            to encrypt. If a sentence here is not true of the code that ships, it is a
            defect, not a slogan.
          </>
        }
        badges={
          <>
            <E2EEBadge size="md" label="Messages · Calls · Location · Moments" />
            <E2EEBadge state="public" size="md" label="Clips · Creator profiles · Games" />
          </>
        }
        actions={
          <ButtonRow>
            <Button href="#what-we-hold" size="lg">
              See what we actually hold
            </Button>
            <Button href="#your-rights" variant="secondary" size="lg">
              Your rights, and where we are
            </Button>
          </ButtonRow>
        }
        aside={<LockMotif size={470} idPrefix="privacy-motif" />}
        note="This site has no analytics, no cookies and no form. Reading it tells us nothing about you."
      />

      {/* ================================================================
       * 1. The mechanism
       * ============================================================= */}
      <Section
        id="how"
        hue="privacy"
        eyebrow="The mechanism"
        title="What happens to a message, step by step."
        lede={
          <>
            End-to-end encryption is not a setting we switch on for you. It is a
            consequence of where the keys live &mdash; and the keys live on your phone.
          </>
        }
      >
        <Split
          aside={
            <div className={styles.custody}>
              <h3 className={styles.custodyTitle}>Who holds which key</h3>
              <ul className={styles.custodyList}>
                <li>
                  <span className={styles.custodyWho}>Your device</span>
                  <span className={styles.custodyWhat}>
                    The private identity key, in hardware-backed storage. Message and group
                    session state. Media keys. Your backup secret.
                  </span>
                </li>
                <li>
                  <span className={styles.custodyWho}>Our servers</span>
                  <span className={styles.custodyWhat}>
                    Public keys, so strangers can start a conversation with you. Opaque
                    ciphertext. Nothing that opens any of it.
                  </span>
                </li>
              </ul>
              <p className={styles.custodyNote}>
                <Glyph name="shield" size={16} />
                <span>
                  Both apps have a safety-number screen, so you can check with a friend
                  in person that no one has been swapped into the middle of your
                  conversation.
                </span>
              </p>
            </div>
          }
        >
          <ol className={styles.steps}>
            <li>
              <strong>The keys are made on the device, and stay there.</strong> Every phone
              you sign in on generates its own key pair. The private half is written to
              hardware-backed storage and never leaves. We are sent the public half only,
              which is all anyone needs to seal something you can open and no help at all
              for opening it.
            </li>
            <li>
              <strong>Your phone encrypts once per device, not once per person.</strong> If
              your friend has a phone and a linked laptop, and you have two devices of your
              own, that one message is sealed separately for each of them. We store one
              opaque blob per recipient device. Group chats use MLS &mdash; the IETF
              standard, RFC 9420 &mdash; and we relay its control messages without ever
              holding a group key.
            </li>
            <li>
              <strong>We store it and route it, and that is the whole job.</strong> The
              message table has a ciphertext column and no plaintext one. Photos, voice
              notes and files are encrypted on your phone and uploaded as encrypted bytes;
              the database keeps a pointer to them and nothing else.
            </li>
            <li>
              <strong>It opens on their device. We learn one thing: that it arrived.</strong>{' '}
              A timestamp against a device, so we know to stop trying. Not a word of what it
              said.
            </li>
          </ol>

          <Callout title="The honest cost of holding no key.">
            <p>
              If you lose every device you own, we cannot bring your history back, because
              there is nothing on our side to bring back. Your backup is encrypted on your
              phone before it is uploaded; the key is wrapped by your PIN or derived from
              your recovery phrase, and both stay with you. A wrong PIN fails on your
              device, not on ours. Keep the recovery phrase somewhere real.
            </p>
          </Callout>
        </Split>
      </Section>

      {/* ================================================================
       * 2. Metadata — the envelope
       * ============================================================= */}
      <Section
        id="what-we-hold"
        hue="privacy"
        tone="raised"
        eyebrow="Metadata"
        title="Encryption hides the letter. It does not hide the envelope."
        lede={
          <>
            This is the part most apps leave vague, so here it is in full. To deliver
            anything at all, a server has to know where it is going. What follows is the
            complete list of what that leaves us holding &mdash; and what it does not.
          </>
        }
      >
        <EnvelopeDiagram />

        <dl className={styles.inventory}>
          {METADATA.map((entry) => (
            <div key={entry.term} className={styles.invRow}>
              <dt className={styles.invTerm}>{entry.term}</dt>
              <dd className={styles.invBody}>
                <p className={styles.invSees}>
                  <span className={styles.invTag}>We see</span>
                  {entry.sees}
                </p>
                <p className={styles.invBlind}>
                  <span className={[styles.invTag, styles.invTagBlind].join(' ')}>
                    We don&rsquo;t
                  </span>
                  {entry.blind}
                </p>
              </dd>
            </div>
          ))}
        </dl>

        <Callout tone="note" glyph="group" title="A related choice, for the same reason.">
          <p>
            Knowing your number is not permission to message you. A chat opens directly
            only between people who have each other saved; a one-way contact arrives as a
            request you can decline, and someone who found you by @username also needs the
            six-digit contact PIN you gave them &mdash; and still only gets to send a
            request. Following a creator adds no fourth path: a creator with a million
            followers has a million people who can watch their clips and no extra people
            who can message them.
          </p>
        </Callout>
      </Section>

      {/* ================================================================
       * 3. What is not encrypted — the amber moment lives here
       * ============================================================= */}
      <Section
        id="not-encrypted"
        hue="privacy"
        eyebrow="The exceptions"
        title="Three surfaces we deliberately did not encrypt."
        lede={
          <>
            An app that claims everything is encrypted is either lying or has not built
            anything public. Voiid has, so here is the line and which side each feature
            sits on. None of these touches your messages, and none of them is a precedent
            for weakening the ones that are encrypted.
          </>
        }
      >
        <Grid columns={3} gap="md">
          <FeatureCard
            title="Clips"
            glyph="clips"
            hue="privacy"
            meta={<E2EEBadge state="public" />}
          >
            <p>
              The video, the caption and the thumbnail are stored in the clear, and we
              count every view. A clip has no recipient list at the moment you post it
              &mdash; anyone may find it later, including people who have not joined yet.
              You cannot encrypt a broadcast to an audience that does not exist, and a
              server that cannot read a row cannot count it.
            </p>
          </FeatureCard>

          <FeatureCard
            title="Creator profiles"
            glyph="broadcast"
            hue="privacy"
            meta={<E2EEBadge state="public" />}
          >
            <p>
              Your creator handle, bio, follower count, and every follow, like and comment
              are readable by us. That is what a public identity is: it is shown to
              strangers, it is searchable, and its counts are ours to attribute. It is a
              separate record from your account for exactly this reason &mdash; the public
              graph and the who-may-message-you graph must never be joinable by accident.
            </p>
          </FeatureCard>

          <FeatureCard
            title="Games"
            glyph="games"
            hue="privacy"
            meta={<E2EEBadge state="refereed" />}
          >
            <p>
              The server referees the match, so it reads the moves. That is the entire
              point: a referee who cannot see the board cannot stop a modified client
              claiming a move that never happened. The invite that started the game
              travelled the ordinary encrypted message pipe, like anything else in the
              chat.
            </p>
          </FeatureCard>
        </Grid>

        <div className={styles.neverList}>
          <h3 className={styles.neverTitle}>
            <Glyph name="eye-off" size={19} />
            And the things we do not collect at all
          </h3>
          <ul>
            <li>No advertising identifier, and no advertising SDK.</li>
            <li>No analytics SDK and no behavioural telemetry &mdash; nothing measures what you tap.</li>
            <li>
              No device fingerprint: not screen metrics, not locale or timezone probes, not
              battery, not network type.
            </li>
            <li>No IP address on your device record, and no coarse location derived from one.</li>
            <li>
              No raw address book. Contact matching happens on your phone and the book
              itself is never uploaded.
            </li>
            <li>
              No content in a push notification. A push is a wake-up; the message is fetched
              and decrypted by the app afterwards.
            </li>
          </ul>
        </div>
      </Section>

      {/* ================================================================
       * 4. DPDP posture
       * ============================================================= */}
      <Section
        id="your-rights"
        hue="privacy"
        eyebrow="Digital Personal Data Protection Act, 2023"
        title="Your rights, and exactly how far we have got."
        lede={
          <>
            Voiid is built in India and is a Data Fiduciary under the DPDP Act. The Act
            gives you rights; this section is what we have committed to, paired with an
            honest note on what you can actually do today and what is still on its way.
            We are pre-launch, and a page that blurred the two would be the first thing
            here you could not trust. It is updated as each piece lands.
          </>
        }
      >
        <Grid columns={3} gap="md">
          {RIGHTS.map((right) => (
            <article key={right.title} className={styles.right}>
              <span className={styles.rightRail} aria-hidden="true" />
              <div className={styles.rightHead}>
                <h3 className={styles.rightTitle}>{right.title}</h3>
                <span className={styles.rightSection}>{right.section}</span>
              </div>
              <p className={styles.rightBody}>{right.commitment}</p>
              <div className={[styles.status, styles[right.state]].join(' ')}>
                <span className={styles.statusChip}>
                  <Glyph
                    name={right.state === 'live' ? 'check' : 'note'}
                    size={14}
                  />
                  {STATE_COPY[right.state]}
                </span>
                <p>{right.stands}</p>
              </div>
            </article>
          ))}
        </Grid>

        {/*
         * tone="honest", not "warn", for two reasons. The obvious one: --color-warning
         * is amber in the dark theme and this page has already spent its one amber on
         * the Server-refereed badge. The better one: "honest" is documented as the tone
         * for the sentence about what we cannot claim, and that is exactly what this is.
         * A warning stripe would also frame a disclosure as a hazard.
         */}
        <Callout
          glyph="shield"
          title="This is a statement of intent. It is not a compliance certificate."
        >
          <p>
            Several questions that decide what compliance actually requires of a product
            like this are open, and they are questions for India-qualified counsel rather
            than for engineers: how long metadata may be kept and whether those periods
            must appear in the notice; whether an anonymised consent record has to survive
            an erasure request as evidence; what &ldquo;verifiable parental consent&rdquo;
            can mean for a signup that knows only a phone number, and what age gate follows
            from it; how far the Eighth-Schedule translation obligation reaches for an app
            this size; and where our storage and telephony providers stand under the
            cross-border rules. We have not had those answers yet. Every retention period
            below is an engineering proposal, marked unreviewed in our own schema, and we
            are not going to describe an unreviewed number as a policy.
          </p>
        </Callout>

        <h3 className={styles.tableTitle}>What we keep, and for how long</h3>
        <div className={['scrollX', styles.tableWrap].join(' ')}>
          <table className={styles.table}>
            <caption className="srOnly">
              Personal data Voiid holds, the purpose for holding it, and the declared
              retention period.
            </caption>
            <thead>
              <tr>
                <th scope="col">What</th>
                <th scope="col">Why we hold it</th>
                <th scope="col">How long</th>
              </tr>
            </thead>
            <tbody>
              {RETENTION.map((row) => (
                <tr key={row.what}>
                  <th scope="row">{row.what}</th>
                  <td>{row.why}</td>
                  <td className={styles.tableHow}>{row.how}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className={styles.tableNote}>
          Declared, and not yet reviewed. These periods live in our schema as the stated
          policy and in the sweep that enforces them as a named constant, so changing one
          is a code change somebody has to read rather than an edit in a console at 2am.
          The sweep records what it deleted and when, which is what makes &ldquo;we have a
          policy&rdquo; and &ldquo;the policy was applied&rdquo; two different, checkable
          things. What none of the durations has yet is a lawyer&rsquo;s sign-off, and our
          own schema carries a field recording that.
        </p>
      </Section>

      {/* ================================================================
       * 5. Grievance officer
       * ============================================================= */}
      <Section
        id="grievance"
        hue="privacy"
        tone="inset"
        width="narrow"
        eyebrow="Section 13"
        title="Grievance Officer"
        lede={
          <>
            The Act requires a published contact who can answer questions about how your
            personal data is handled. The IT Rules, 2021 separately require a named officer
            with an address in India for complaints about content.
          </>
        }
      >
        <dl className={styles.grievance}>
          <div>
            <dt>Name</dt>
            <dd>
              <Pending field={CONTACT.grievance.name} />
            </dd>
          </div>
          <div>
            <dt>Email</dt>
            <dd>
              <Pending field={CONTACT.grievance.email} />
            </dd>
          </div>
          <div>
            <dt>Address in India</dt>
            <dd>
              <Pending field={CONTACT.grievance.address} />
            </dd>
          </div>
          <div>
            <dt>Response time</dt>
            <dd>
              <Pending field={CONTACT.grievance.responseWindow} />
            </dd>
          </div>
        </dl>

        {CONTACT_INCOMPLETE ? (
          <Callout title="Why these fields are empty rather than filled in.">
            <p>
              We have not appointed the officer yet. An invented name and an unmonitored
              inbox would be worse than a blank: someone would write to it, hear nothing,
              and believe they had exercised a right they had not. When the appointment is
              real, the details appear here and in the footer of every page.
            </p>
          </Callout>
        ) : null}
      </Section>

      <CTA
        hue="privacy"
        title={<>If a sentence on this page is wrong, that is a bug.</>}
        lede={
          <>
            Every claim here was checked against the code that ships, and the parts that
            are not built yet say so. If you find one that does not hold, the security
            contact in the footer is where to send it.
          </>
        }
        actions={
          <ButtonRow align="center">
            <Button href="/messaging" size="lg">
              How messaging works
            </Button>
            <Button href="/clips" variant="secondary" size="lg">
              Why clips are public
            </Button>
          </ButtonRow>
        }
        note="No sign-up on this site, no tracker on this page, and no store links until the apps are actually in the stores."
      />
    </>
  );
}
