import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid } from '../../components/Section';
import { FeatureCard } from '../../components/FeatureCard';
import { Callout } from '../../components/Callout';
import { E2EEBadge } from '../../components/E2EEBadge';
import { LockMotif } from '../../components/LockMotif';
import styles from './page.module.css';

export const metadata: Metadata = {
  title: 'Privacy',
  description:
    'What is end-to-end encrypted, what deliberately is not, and exactly what our ' +
    'servers can see. Written to be checked, not to reassure.',
};

/*
 * THE PAGE THIS SITE EXISTS TO BE ABLE TO WRITE. Two rules held throughout:
 *
 *  1. Every row of the table below is checked against a migration header. If a claim
 *     here and the schema disagree, the schema is right and this page is a bug.
 *  2. DPDP obligations are described as COMMITMENTS, never as certifications. Where
 *     docs/research/11_admin_dpdp.md flags a question as needing counsel, that is said
 *     plainly rather than resolved by a marketing page.
 */

type Row = { surface: string; state: 'e2ee' | 'public' | 'refereed'; detail: string };

const ROWS: Row[] = [
  { surface: 'Messages, one-to-one and group', state: 'e2ee',
    detail: 'Encrypted per recipient device. We relay ciphertext and hold no key.' },
  { surface: 'Voice and video calls', state: 'e2ee',
    detail: 'Media and keys are derived on the devices. We keep the call log, never the call.' },
  { surface: 'Location shares and the map', state: 'e2ee',
    detail: 'Positions are encrypted on your phone and never written to our database.' },
  { surface: 'Moments', state: 'e2ee',
    detail: 'Encrypted to a known audience, one key envelope per recipient device.' },
  { surface: 'Clips, captions and thumbnails', state: 'public',
    detail: 'Stored as plaintext. We can read them. A broadcast has no recipient list to encrypt to.' },
  { surface: 'Creator profiles, follows, likes, comments', state: 'public',
    detail: 'Server-readable. They are public identity and public counts by design.' },
  { surface: 'Game moves, scores and results', state: 'refereed',
    detail: 'Our server is the referee, so it reads the moves. The invite is an encrypted message.' },
];

export default function PrivacyPage() {
  return (
    <>
      <Hero
        hue="privacy"
        eyebrow="Privacy"
        title={<>What we can see, written down.</>}
        lede={
          <>
            Every app says it is private. The useful question is narrower: which parts are
            encrypted so that we could not read them if we wanted to, which parts are not, and
            what is left over either way. Here is our answer to all three.
          </>
        }
        aside={<LockMotif />}
      />

      <Section
        hue="privacy"
        eyebrow="Surface by surface"
        title="Encrypted, and not"
        lede="If this table and the code ever disagree, the code is right and this page is a bug."
        width="wide"
      >
        <div className={styles.tableWrap}>
          <table className={styles.table}>
            <thead>
              <tr><th scope="col">Surface</th><th scope="col">State</th><th scope="col">What that means</th></tr>
            </thead>
            <tbody>
              {ROWS.map((r) => (
                <tr key={r.surface}>
                  <th scope="row">{r.surface}</th>
                  <td><E2EEBadge state={r.state} size="sm" /></td>
                  <td>{r.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Section>

      <Section
        hue="privacy"
        tone="raised"
        eyebrow="Metadata"
        title="The part nobody likes to talk about"
        width="narrow"
      >
        <p>
          Encryption protects content. It does not hide that a conversation happened. To deliver
          a message at all, we necessarily hold some of this:
        </p>
        <ul>
          <li>Which accounts exchange messages, and when — not what they said.</li>
          <li>Your phone number, because it is how an account is verified.</li>
          <li>Device type and app version, so we can ship updates that work.</li>
          <li>IP addresses on connection, which is unavoidable for anything on the internet.</li>
          <li>Call records: who, when, how long.</li>
        </ul>
        <Callout tone="honest" title="We would rather name it than imply it away">
          A service that claims to see nothing at all is either not delivering your messages or
          not telling you the truth. What we can promise is that we do not hold your content,
          and that we keep the rest for as short a time as the feature allows.
        </Callout>
      </Section>

      <Section hue="privacy" eyebrow="Your rights" title="Under India&rsquo;s DPDP Act">
        <Grid>
          <FeatureCard title="Access and correction" glyph="note" hue="privacy">
            You can ask what personal data we hold about you and have it corrected. Because
            your messages are encrypted, an export contains metadata — we cannot produce
            content we cannot read.
          </FeatureCard>
          <FeatureCard title="Erasure" glyph="shield" hue="privacy">
            Deleting your account starts a real erasure, not a hidden flag: an automated job
            removes your rows and your uploaded media, and your sessions stop working
            immediately rather than when a token happens to expire.
          </FeatureCard>
          <FeatureCard title="Consent you can withdraw" glyph="check" hue="privacy">
            Withdrawing consent is built to be as easy as giving it, and we record which
            version of which notice you agreed to, so &ldquo;what did I actually agree to&rdquo;
            has an answer.
          </FeatureCard>
        </Grid>
        <Callout tone="note" title="Where we are, honestly">
          These are commitments and the controls behind them are being built — not a
          certification. Some questions the Act raises for an encrypted messenger have answers
          that need a lawyer rather than an engineer, and we are not going to pretend on a
          marketing page that we have settled them. A grievance-officer contact is published in
          the footer.
        </Callout>
      </Section>

      <Section hue="privacy" eyebrow="What this page is not" title="No promises we cannot keep" width="narrow">
        <p>
          We have not been independently audited. Our encryption is built on well-reviewed
          public building blocks — the Double Ratchet for one-to-one, MLS for groups — but
          using good primitives is not the same as having someone check that we used them
          correctly, and we are not going to blur that line.
        </p>
        <p>
          When something is not finished, the rest of this site says so rather than listing it.
          That is the standard we would want to read.
        </p>
      </Section>
    </>
  );
}
