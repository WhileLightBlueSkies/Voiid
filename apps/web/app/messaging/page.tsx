import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid, Split } from '../../components/Section';
import { FeatureCard } from '../../components/FeatureCard';
import { Callout } from '../../components/Callout';
import { E2EEBadge } from '../../components/E2EEBadge';
import { CTA } from '../../components/CTA';
import { PhoneMockup, PhoneAppBar, ChatBubble } from '../../components/PhoneMockup';

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
            <PhoneAppBar title="Priyanshu" subtitle="online" />
            <ChatBubble>Did the build pass?</ChatBubble>
            <ChatBubble side="sent">Green on both platforms.</ChatBubble>
            <ChatBubble side="sent">Pushing now.</ChatBubble>
          </PhoneMockup>
        }
      />

      <Section
        hue="chat"
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
        <Grid>
          <FeatureCard title="You already have each other saved" glyph="check" hue="chat">
            The chat opens directly. Mutual contacts are the one case where both people have
            already made the decision, so there is nothing left to ask.
          </FeatureCard>
          <FeatureCard title="Only one of you has the other saved" glyph="note" hue="chat">
            It arrives as a request you can accept or decline. Having someone&rsquo;s number is
            not consent — treating it as consent is exactly what turns a leaked list into
            spam everywhere else.
          </FeatureCard>
          <FeatureCard title="They found your @username" glyph="key" hue="chat">
            A username alone gets them nowhere. They also need your six-digit contact PIN,
            which you give out yourself — out loud, on a card, however you like — and it
            still only opens a request.
          </FeatureCard>
        </Grid>
        <Callout tone="note" title="The PIN is not a password">
          It cannot log anyone in and it protects nothing but your inbox. It is a
          proof-of-acquaintance token: six digits are enough to stop someone guessing their
          way to you at scale, and small enough to read out over a phone call.
        </Callout>
      </Section>

      <Section hue="chat" tone="raised" eyebrow="Groups" title="Groups that stay encrypted as they grow">
        <Split
          aside={
            <PhoneMockup hue="chat" size="sm" tilt="right" label="A group conversation" decorative>
              <PhoneAppBar title="Launch team" subtitle="9 members" />
              <ChatBubble>Ship it?</ChatBubble>
              <ChatBubble side="sent">Ship it.</ChatBubble>
            </PhoneMockup>
          }
        >
          <div>
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
        lede="What is end-to-end encrypted, what deliberately is not, and precisely what our servers can see."
        actions={<></>}
        note={<>See the <a href="/privacy">privacy page</a>.</>}
      />
    </>
  );
}
