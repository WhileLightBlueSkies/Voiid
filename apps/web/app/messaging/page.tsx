import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Split } from '../../components/Section';
import { MessageJourney } from '../../components/MessageJourney';
import { ReachabilityDemo } from '../../components/ReachabilityDemo';
import { Callout } from '../../components/Callout';
import { E2EEBadge } from '../../components/E2EEBadge';
import { CTA } from '../../components/CTA';
import { Button, ButtonRow } from '../../components/Button';
import { Glyph } from '../../components/Glyph';
import { PhoneMockup, PhoneAppBar, ChatBubble, PhoneAvatar } from '../../components/PhoneMockup';
import styles from './page.module.css';

export const metadata: Metadata = {
  title: 'Messaging',
  description:
    'End-to-end encrypted chats and groups. Reaching you takes more than knowing your ' +
    'number — mutual contacts, or your @username and a PIN you hand out yourself.',
};

/*
 * CLAIMS CHECKED, per apps/web/README.md rule 2:
 *   - Messages are E2EE per recipient DEVICE — 006_messages.sql, 013_message_ciphertexts.sql.
 *   - Groups run on MLS — 011_mls.sql.
 *   - The three reachability paths and the 6-digit PIN — 020_reachability.sql.
 *   - Note to Self is a real conversation type — conversations.type = 'self'.
 * Nothing here claims disappearing messages, backups or a desktop app.
 */

const JOURNEY = [
  {
    glyph: 'device' as const,
    title: 'Sealed on your phone',
    body: 'Your device encrypts the message for each recipient device, with keys that never leave the keychain.',
  },
  {
    glyph: 'broadcast' as const,
    title: 'Relayed blind',
    // The one leg where we carry the message and cannot read it. The rail is
    // drawn dashed across exactly this step.
    blind: true,
    body: 'Our server moves opaque ciphertext. It sees which device gets which envelope \u2014 never what is inside one.',
  },
  {
    glyph: 'lock' as const,
    title: 'Opened on theirs',
    body: 'Only the recipient\u2019s devices hold the private half. To everyone else, including us, it is noise.',
  },
];

export default function MessagingPage() {
  return (
    <>
      <Hero
        hue="chat"
        eyebrow="Messaging"
        title={<>Encrypted by default. Reachable on your terms.</>}
        lede={
          <>
            Every message is encrypted on your device and decrypted on theirs. We relay
            ciphertext we cannot read — not as a setting you turn on, but as the only thing
            the server is built to carry.
          </>
        }
        badges={<E2EEBadge state="e2ee" detail="Messages and groups" />}
        aside={
          <PhoneMockup hue="chat" tilt="left" label="A one-to-one chat" decorative>
            <PhoneAppBar
              title="Priyanshu"
              subtitle="End-to-end encrypted"
              trailing={<Glyph name="call" size={16} />}
            />
            <ChatBubble>Did the build pass?</ChatBubble>
            <ChatBubble side="sent">Green on both platforms.</ChatBubble>
            <ChatBubble side="sent">Pushing now.</ChatBubble>
            <ChatBubble>Legend. Testing the new build now</ChatBubble>
          </PhoneMockup>
        }
      />

      {/* ---- how a message travels ------------------------------------------- */}
      <Section
        hue="chat"
        eyebrow="The path of a message"
        title="Three steps, and we are blind for the middle one."
        lede={
          <>
            End-to-end is a statement about the whole journey, not about either end. Here
            is the entire trip your message takes — there is no fourth step where anyone
            reads it.
          </>
        }
      >
        <MessageJourney steps={JOURNEY} />
      </Section>

      <Section
        hue="chat"
        tone="raised"
        eyebrow="Reachability"
        title="Knowing your number is not the same as being able to message you"
        lede={
          <>
            Most apps treat a phone number as a permanent invitation. A leaked contact list
            becomes a spam list, and there is nothing you can do about it. Voiid separates
            being findable from being reachable.
          </>
        }
      >
        <ReachabilityDemo />
        <Callout tone="note" title="The PIN is not a password" className={styles.afterDemo}>
          It cannot log anyone in and it protects nothing but your inbox. It is a
          proof-of-acquaintance token: six digits are enough to stop someone guessing their
          way to you at scale, and small enough to read out over a phone call.
        </Callout>
      </Section>

      <Section hue="chat" eyebrow="Groups" title="Groups that stay encrypted as they grow">
        <Split
          aside={
            <PhoneMockup hue="chat" size="sm" tilt="right" label="A group conversation" decorative>
              <PhoneAppBar title="Launch team" subtitle="9 members · encrypted" />
              <ChatBubble>Ship it?</ChatBubble>
              <ChatBubble side="sent">Ship it.</ChatBubble>
            </PhoneMockup>
          }
        >
          <div className={styles.proseFlow}>
            <p>
              Group chats use MLS, the IETF standard for continuous group key agreement. Every
              member holds a share of the group key; adding or removing someone rolls it, so a
              person who leaves cannot read what is said afterwards and a person who joins
              cannot read what came before.
            </p>
            <p>
              Roles are real: one owner, who can hand ownership on, and admins who can manage
              membership. Role changes appear in the conversation itself rather than happening
              invisibly.
            </p>
          </div>
        </Split>
      </Section>

      <Section hue="chat" eyebrow="Note to Self" title="A conversation with nobody but you" width="narrow">
        <p>
          Note to Self is a real chat, not a scratchpad bolted onto the side. It syncs to your
          own linked devices and nowhere else — encrypted to your other devices exactly the way
          a message to a friend is encrypted to theirs. On a single device there is no one to
          encrypt to, so the note simply stays where you wrote it.
        </p>
      </Section>

      <CTA
        hue="chat"
        title="Read the encryption story in full"
        lede="Every primitive we encrypt with, what deliberately stays public, and precisely what our servers can see."
        actions={
          <ButtonRow align="center">
            <Button href="/encryption" size="lg">
              See the encryption stack
            </Button>
            <Button href="/privacy" variant="secondary" size="lg">
              What we can see
            </Button>
          </ButtonRow>
        }
      />
    </>
  );
}
