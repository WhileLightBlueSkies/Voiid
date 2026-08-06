import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { Hero } from '../components/Hero';
import { Section, Grid, Split } from '../components/Section';
import { FeatureCard } from '../components/FeatureCard';
import { CTA } from '../components/CTA';
import { Button, ButtonRow } from '../components/Button';
import { E2EEBadge } from '../components/E2EEBadge';
import { LockMotif } from '../components/LockMotif';
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

type FeatureEntry = {
  href: string;
  title: string;
  hue: DomainHue;
  glyph: GlyphName;
  body: string;
  badge: ReactNode;
  cta: string;
  span?: 1 | 2;
};

const FEATURES: FeatureEntry[] = [
  {
    href: '/messaging',
    title: 'Messaging',
    hue: 'chat',
    glyph: 'chat',
    body:
      'One-to-one and group chats, encrypted end to end. You decide who is allowed ' +
      'to reach you before a stranger can start a conversation at all.',
    badge: <E2EEBadge state="e2ee" />,
    cta: 'How messaging works',
  },
  {
    href: '/calls',
    title: 'Calls',
    hue: 'calls',
    glyph: 'call',
    body:
      'Voice and video, one to one or as a group. The call itself is end-to-end ' +
      'encrypted. We keep the log — who called whom, and for how long — not the call.',
    badge: <E2EEBadge state="e2ee" />,
    cta: 'How calls work',
  },
  {
    href: '/map',
    title: 'Map',
    hue: 'map',
    glyph: 'map',
    body:
      'A live map of the friends who chose to share with you — at the precision they ' +
      'picked, for as long as they said, and not a minute longer. Encrypted in transit ' +
      'and at rest on our side.',
    badge: <E2EEBadge state="e2ee" />,
    cta: 'How the map works',
  },
  {
    href: '/clips',
    title: 'Clips',
    hue: 'clips',
    glyph: 'clips',
    body:
      'Short public video, creator profiles and follows. Public means public: our ' +
      'server stores the video and the caption in the clear, and counts every view. ' +
      'You cannot encrypt a broadcast to an audience that has not signed up yet.',
    badge: <E2EEBadge state="public" />,
    cta: 'What clips are, exactly',
  },
  {
    href: '/games',
    title: 'Games',
    hue: 'games',
    glyph: 'games',
    body:
      'Tic Tac Toe, Rock Paper Scissors, Snake and Hand Cricket, played inside a chat. ' +
      'The server referees the match, so it reads the moves — otherwise a modified ' +
      'client could claim any move it liked. The invite that started it travelled ' +
      'encrypted like any other message.',
    badge: <E2EEBadge state="refereed" />,
    cta: 'See the catalogue',
  },
  {
    href: '/privacy',
    title: 'Privacy',
    hue: 'privacy',
    glyph: 'privacy',
    body:
      'The architecture in plain language: where the keys live, what leaves your ' +
      'phone, and the complete list of what we can see if we look.',
    badge: <E2EEBadge state="e2ee" label="Read the whole thing" />,
    cta: 'Read the architecture',
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
            <Button href="/privacy" size="lg">
              See exactly what we can&rsquo;t see
            </Button>
            <Button href="/messaging" variant="secondary" size="lg">
              Start with messaging
            </Button>
          </ButtonRow>
        }
        aside={<LockMotif size={480} idPrefix="hero-motif" />}
      />

      {/* ---- the feature grid ------------------------------------------------ */}
      <Section
        id="features"
        eyebrow="Everything in one place"
        title="Five things you keep five apps for."
        lede={
          <>
            Each one is built on the same key material and the same account. Each one is
            labelled with what it actually does with your data — including the two that
            are not private.
          </>
        }
      >
        <Grid columns={3} gap="md">
          {FEATURES.map((f) => (
            <FeatureCard
              key={f.href}
              href={f.href}
              title={f.title}
              hue={f.hue}
              glyph={f.glyph}
              meta={f.badge}
              cta={f.cta}
              span={f.span}
            >
              <p>{f.body}</p>
            </FeatureCard>
          ))}
        </Grid>
      </Section>

      {/* ---- the honesty section: the actual differentiator ------------------ */}
      <Section
        id="what-we-see"
        tone="raised"
        hue="chat"
        eyebrow="The part most apps skip"
        title="Here is the line, and here is which side each feature sits on."
        lede={
          <>
            An app that says &ldquo;private&rdquo; on every screen is telling you nothing.
            So this is the whole picture, on the home page, before you have downloaded
            anything.
          </>
        }
      >
        <Split
          aside={
            <PhoneMockup
              hue="chat"
              size="md"
              tilt="right"
              label="A Voiid chat. The conversation header shows that the chat is end-to-end encrypted."
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
        >
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
        </Split>
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
