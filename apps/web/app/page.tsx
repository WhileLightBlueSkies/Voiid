import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { Hero } from '../components/Hero';
import { Section } from '../components/Section';
import { SurfaceTour, type Surface } from '../components/SurfaceTour';
import { CTA } from '../components/CTA';
import { Button, ButtonRow } from '../components/Button';
import { E2EEBadge } from '../components/E2EEBadge';
import { Callout } from '../components/Callout';
import { Glyph, type GlyphName } from '../components/Glyph';
import {
  PhoneMockup,
  PhoneAppBar,
  ChatBubble,
  PhoneAvatar,
} from '../components/PhoneMockup';
import type { DomainHue } from '../lib/hues';
import styles from './page.module.css';

export const metadata: Metadata = {
  // The layout template appends "— Voiid"; the home title stands alone.
  title: 'Voiid — one encrypted app for chat, calls, the map, clips and games',
  description:
    'Messages, calls, location shares and moments are end-to-end encrypted — we hold ' +
    'no key. Clips and games are public, and we say so. Built in India, for the world.',
};

/*
 * EVERY CLAIM ON THIS PAGE IS CHECKED AGAINST THE SCHEMA. In particular:
 *   - E2EE surfaces: messages (006/013), calls (014), location shares (018),
 *     moments/stories (017).
 *   - NOT E2EE, deliberately: clips + creator profiles (022, 029) and game state
 *     (024). Both migration headers explain why, and both say the server can read.
 *   - The games catalogue is exactly four: 024 seeds tictactoe + rps, 025 seeds
 *     cricket, 026 seeds snake. Do not add a fifth here before it is seeded there.
 *   - There are no store links yet, so this page does not pretend there are.
 */

const SURFACES: Surface[] = [
  {
    href: '/messaging',
    index: '01',
    title: 'Chats nobody else can open',
    body:
      'One-to-one and group messages, sealed on your device for each recipient device. ' +
      'You decide who can reach you before a stranger can start a conversation at all.',
    hue: 'chat',
    stance: <E2EEBadge state="e2ee" />,
    cta: 'How messaging works',
    proof: (
      <PhoneMockup hue="chat" size="md" tilt="left" label="A one-to-one chat" decorative>
        <PhoneAppBar
          title="Aditi"
          subtitle="End-to-end encrypted"
          trailing={<Glyph name="call" size={16} />}
        />
        <ChatBubble side="received">Landed. Sharing my location for the next hour?</ChatBubble>
        <ChatBubble side="sent" meta="19:04">Please do — I&rsquo;ll start walking over.</ChatBubble>
        <ChatBubble side="received">Shared. It stops on its own at 20:04.</ChatBubble>
      </PhoneMockup>
    ),
  },
  {
    href: '/calls',
    index: '02',
    title: 'Calls we route but never hear',
    body:
      'Voice and video, one to one or as a group, encrypted frame by frame. We keep the ' +
      'log — who called whom, and for how long — because a missed call has to be a record ' +
      'of something. We never keep the call.',
    hue: 'calls',
    stance: <E2EEBadge state="e2ee" />,
    cta: 'How calls work',
    proof: (
      <PhoneMockup hue="calls" size="md" tilt="right" label="An encrypted call" decorative>
        <PhoneAppBar title="Nehal" subtitle="Encrypted · 04:12" />
        {/* Matches CallScreens.swift: name 24 bold, status 14 with tabular
            digits, then the keying badge — which reads "End-to-end encrypted ·
            verified" and is textSecondary on a surfaceCard capsule, NOT green.
            A security indicator that can only ever say something good is
            decoration; this one has four states and green is not the default. */}
        <div className={styles.callProof}>
          <span className={styles.callName}>Nehal</span>
          <span className={styles.callStatus}>04:12</span>
          <span className={styles.callBadge}>
            <Glyph name="lock" size={11} />
            End-to-end encrypted · verified
          </span>
          <span className={styles.callControls} aria-hidden="true">
            <span className={styles.ctl}><Glyph name="device" size={13} /></span>
            <span className={styles.ctl}><Glyph name="eye-off" size={13} /></span>
            <span className={`${styles.ctl} ${styles.ctlEnd}`}><Glyph name="call" size={13} /></span>
          </span>
        </div>
      </PhoneMockup>
    ),
  },
  {
    href: '/map',
    index: '03',
    title: 'A map that forgets on schedule',
    body:
      'See the friends who chose to share with you, at the precision they picked, for as ' +
      'long as they said. Every share carries its own expiry — you do not have to remember ' +
      'to turn it off.',
    hue: 'map',
    stance: <E2EEBadge state="e2ee" />,
    cta: 'How the map works',
    proof: (
      <PhoneMockup hue="map" size="md" tilt="left" label="Live location sharing" decorative>
        <PhoneAppBar title="Map" subtitle="2 friends sharing" />
        {/* Matches Map/MapHeader.swift: the always-visible answer to "can
            anyone see me?" is a 11pt line in accentInk beside the title, with a
            38pt ghost-toggle circle on surfaceCard at the trailing edge. */}
        <div className={styles.mapProof}>
          <span className={styles.mapStatus}>
            <Glyph name="broadcast" size={9} />
            Visible · 2 friends sharing
          </span>
          <span className={styles.mapPin} />
          <span className={styles.mapGhost} aria-hidden="true">
            <Glyph name="eye-off" size={14} />
          </span>
        </div>
      </PhoneMockup>
    ),
  },
  {
    href: '/clips',
    index: '04',
    title: 'Clips, and we say they are public',
    body:
      'Short public video, creator profiles and follows. Public means public: the server ' +
      'stores the video and the caption in the clear and counts every view. You cannot ' +
      'encrypt a broadcast to an audience that has not signed up yet.',
    hue: 'clips',
    stance: <E2EEBadge state="public" />,
    cta: 'What clips are, exactly',
    proof: (
      <PhoneMockup hue="clips" size="md" tilt="right" label="A public clip" decorative>
        <PhoneAppBar title="Clips" subtitle="Public" />
        {/* Matches Clips/ClipsFeedView.swift: a segmented Explore/Following
            capsule (max 280pt, filled primary on the selected half) above a
            3-column grid of 9:16 tiles with 2pt gutters. The old mockup showed
            one portrait frame, which is the FULLSCREEN player, not the feed. */}
        <div className={styles.clipProof}>
          <span className={styles.clipScope} aria-hidden="true">
            <span className={styles.clipScopeOn}>Explore</span>
            <span className={styles.clipScopeOff}>Following</span>
          </span>
          <span className={styles.clipGrid} aria-hidden="true">
            {Array.from({ length: 6 }, (_, i) => (
              <span key={i} className={styles.clipTile} />
            ))}
          </span>
        </div>
      </PhoneMockup>
    ),
  },
  {
    href: '/games',
    index: '05',
    title: 'Games with a referee that sees',
    body:
      'Tic Tac Toe, Rock Paper Scissors, Snake and Hand Cricket, played inside a chat. ' +
      'The server referees, so it reads the moves — otherwise a modified client could ' +
      'claim any move it liked. The invite travelled encrypted like any other message.',
    hue: 'games',
    stance: <E2EEBadge state="refereed" />,
    cta: 'See the catalogue',
    proof: (
      <PhoneMockup hue="games" size="md" tilt="left" label="A game inside a chat" decorative>
        <PhoneAppBar title="Priyanshu" subtitle="Playing Hand Cricket" />
        <ChatBubble side="received">Rematch?</ChatBubble>
        {/* Matches GameInviteBubble in ChatDetailView.swift: a game invite is a
            CARD, not a text bubble — 16:9 artwork panel over a "GAME INVITE"
            label in primary at 10pt bold, then the game name at 16pt bold. */}
        <div className={styles.gameCard} aria-hidden="true">
          <span className={styles.gameArt}>
            <Glyph name="games" size={26} />
          </span>
          <span className={styles.gameBody}>
            <span className={styles.gameKicker}>Game invite</span>
            <span className={styles.gameName}>Hand Cricket</span>
          </span>
        </div>
      </PhoneMockup>
    ),
  },
];

const ENCRYPTED = [
  'The text of every message, one to one and in groups',
  'Photos, videos, voice notes and files you send in a chat',
  'Voice and video calls, including group calls',
  'Live location and the pins you drop into a conversation',
  'Moments you post to a chosen audience',
];

const NOT_ENCRYPTED = [
  'Clips — the video, the caption, the thumbnail',
  'Creator profiles, follows, likes and comments on clips',
  'Game moves, scores and results while a match is running',
  'Who messaged whom and when, and who called whom and when',
];

export default function HomePage() {
  return (
    <>
      <Hero
        hue="chat"
        eyebrow="Built in India · for the world"
        title="One app for chat, calls, the map, clips and games."
        lede={
          <>
            Your messages, calls, location shares and moments are end-to-end encrypted —
            we hold no key and cannot read them, even if we wanted to. Clips and games
            are public by design, and we say so on the tin rather than in a footnote.
          </>
        }
        badges={
          <>
            <E2EEBadge state="e2ee" size="md" label="Messages · Calls · Map · Moments" />
            <E2EEBadge state="public" size="md" label="Clips · Games" />
          </>
        }
        actions={
          <ButtonRow>
            <Button href="/messaging" size="lg">
              Explore Voiid
            </Button>
            <Button href="/privacy" variant="secondary" size="lg">
              See what we can&rsquo;t see
            </Button>
          </ButtonRow>
        }
        /*
         * The hero leads with the PRODUCT, not with a paragraph.
         *
         * This page used to open on centred text alone and hold its only phone
         * back until the fourth section. Every comparable site — WhatsApp,
         * Arattai, Signal — shows the app in the first screen, because a
         * messaging app's strongest argument is what a conversation looks like.
         * The mockup below is the same one the honesty section used; it has
         * simply been moved to where it does the most work.
         */
        aside={
          <PhoneMockup
            hue="chat"
            size="lg"
            tilt="left"
            label="A Voiid chat. The conversation header shows the chat is end-to-end encrypted."
          >
            <PhoneAppBar
              title="Aditi"
              subtitle="End-to-end encrypted"
              trailing={<Glyph name="call" size={16} />}
            />
            <div className={styles.thread}>
              <ChatBubble side="received">
                Landed. Sharing my location for the next hour?
              </ChatBubble>
              <ChatBubble side="sent" meta="19:04">
                Please do — I&rsquo;ll start walking over.
              </ChatBubble>
              <ChatBubble side="received">
                Shared. It stops on its own at 20:04.
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

      {/*
        The tour has NO section header.

        It used to open with eyebrow → h2 → lede, like every other band on the
        page. That preamble is what made the redesign still read as the old page:
        swapping a section's contents changes nothing if the page's skeleton is
        still label / headline / paragraph / content, five times down.

        Split Studio's first band IS the entry. The surfaces announce themselves.
      */}
      <section id="features" aria-label="The five surfaces" className={styles.tourBand}>
        <SurfaceTour surfaces={SURFACES} />
      </section>

      {/* ---- encryption teaser: what's underneath ----------------------------- */}
      <Section
        id="under-the-hood"
        hue="privacy"
        eyebrow="Under the hood"
        title="Built on named cryptography — not vibes."
        lede={
          <>
            One Rust core compiled into every platform. The ratchets and group protocol
            are public standards; the custom glue is small, centralised, and written
            down on its own page.
          </>
        }
      >
        <div className={styles.stackRow}>
          {[
            { name: 'vodozemac', role: 'Double Ratchet · 1:1 chats' },
            { name: 'OpenMLS', role: 'RFC 9420 · groups' },
            { name: 'X-Wing', role: 'ML-KEM-768 · post-quantum' },
            { name: 'AES-256-GCM', role: 'media & attachments' },
          ].map((t) => (
            <div key={t.name} className={styles.stackChip}>
              <span className={styles.stackName}>{t.name}</span>
              <span className={styles.stackRole}>{t.role}</span>
            </div>
          ))}
        </div>
        <ButtonRow className={styles.stackActions}>
          <Button href="/encryption" variant="ghost">
            See every primitive we use
          </Button>
        </ButtonRow>
      </Section>

      {/* ---- the honesty section: the actual differentiator ------------------ */}
      <Section
        id="what-we-see"
        tone="raised"
        hue="chat"
        /*
          No eyebrow, no lede. This band is the page's THESIS, and the two
          sections around it are teasers — dressing all three in the same
          label/headline/paragraph furniture is what made the page read as one
          repeating rhythm regardless of what the sections said. A thesis states
          itself; it does not need a category label above it.
        */
        title={
          <>
            An app that says &ldquo;private&rdquo; on every screen is telling you
            nothing. So here is the line.
          </>
        }
        className={styles.thesis}
      >
        <>
          <div className={styles.ledger}>
            <div className={styles.ledgerCol}>
              <h3 className={styles.ledgerHead}>
                <span className={styles.ledgerIconOk} aria-hidden="true">
                  <Glyph name="lock" size={16} />
                </span>
                We cannot read
              </h3>
              <ul className={styles.ledgerList}>
                {ENCRYPTED.map((item) => (
                  <li key={item}>
                    <Glyph name="check" size={15} className={styles.tick} />
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
            </div>

            <div className={styles.ledgerCol}>
              <h3 className={styles.ledgerHead}>
                <span className={styles.ledgerIconOpen} aria-hidden="true">
                  <Glyph name="broadcast" size={16} />
                </span>
                We can read
              </h3>
              <ul className={[styles.ledgerList, styles.ledgerListOpen].join(' ')}>
                {NOT_ENCRYPTED.map((item) => (
                  <li key={item}>
                    <Glyph name="eye-off" size={15} className={styles.tickOpen} />
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
            </div>
          </div>

          <Callout title="Why the second list exists at all.">
            <p>
              A clip has no recipient list at the moment you post it — anyone may find
              it later, including people who have not joined yet — and a server that
              cannot read a row cannot count a view. A game needs a referee, and a
              referee that cannot see the moves is not one. Both are scoped exceptions
              we chose on purpose. Neither one touches your messages.
            </p>
          </Callout>

          <ButtonRow className={styles.ledgerActions}>
            <Button href="/privacy" variant="ghost">
              Read the full architecture
            </Button>
          </ButtonRow>
        </>
      </Section>

      {/* ---- built in India -------------------------------------------------- */}
      <Section id="origin" hue="map" width="narrow" align="center">
        <div className={styles.origin}>
          <span className={styles.originGlyph} aria-hidden="true">
            <Glyph name="globe" size={26} />
          </span>
          <h2 className={styles.originTitle}>Built in India, for the world.</h2>
          <p className={styles.originBody}>
            Voiid is designed and built in India, under Indian law, by a team that uses
            it every day. It is not an Indian version of something else — the encryption,
            the map, the clips and the games are one codebase, shipping to everyone at
            the same time.
          </p>
        </div>
      </Section>

      {/* ---- close ----------------------------------------------------------- */}
      <CTA
        hue="chat"
        title="Nothing to sign up for on this page."
        lede={
          <>
            There is no form here, no newsletter and no tracker — this site collects
            nothing. When there is something to download, the link will appear here.
          </>
        }
        actions={
          <ButtonRow align="center">
            <Button href="/privacy" size="lg">
              Read the privacy architecture
            </Button>
            <Button href="/messaging" variant="secondary" size="lg">
              Tour the features
            </Button>
          </ButtonRow>
        }
        note="iOS and Android builds are still in testing. App Store and Play links will appear here, and nowhere else on this site, once they exist."
      />
    </>
  );
}
